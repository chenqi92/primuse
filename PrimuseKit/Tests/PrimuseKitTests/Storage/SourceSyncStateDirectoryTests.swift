import Foundation
import Testing
@testable import PrimuseKit

/// 旧版本 `SourceSyncState` 的磁盘形状:索引就是普通字典。用它写出的 JSON 就是旧版本
/// 写的 `source-sync-states.json`,与新代码的编码器无关。
private struct LegacySourceSyncState: Codable {
    var schemaVersion: Int
    var sourceID: String
    var scopeFingerprint: String
    var identityScopeFingerprint: String?
    var cursors: [String: String]
    var index: [String: SourceSyncIndexedItem]
    var pendingDirectories: [String]
    var scanEpoch: Int64
    var requiresDeepScan: Bool
    var lastFullScanAt: Date?
    var lastSuccessfulSyncAt: Date?
    var identityAliases: [String: String]
    var rootIdentities: [SourceSyncRootIdentity]
    var reconciliation: SourceSyncReconciliation?
    var missingStableKeys: [String: Int]
    var missingCatalogSongIDs: [String: Int]
    var deletionEvidenceRevision: String?
    var catalogSyncMarker: ServerCatalogSyncMarker?
    var lastTelemetry: SourceSyncTelemetry?

    var current: SourceSyncState {
        SourceSyncState(
            schemaVersion: schemaVersion, sourceID: sourceID, scopeFingerprint: scopeFingerprint,
            identityScopeFingerprint: identityScopeFingerprint, cursors: cursors, index: SourceSyncIndex(index),
            pendingDirectories: pendingDirectories, scanEpoch: scanEpoch, requiresDeepScan: requiresDeepScan,
            lastFullScanAt: lastFullScanAt, lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            identityAliases: identityAliases, rootIdentities: rootIdentities, reconciliation: reconciliation,
            missingStableKeys: missingStableKeys, missingCatalogSongIDs: missingCatalogSongIDs,
            deletionEvidenceRevision: deletionEvidenceRevision, catalogSyncMarker: catalogSyncMarker,
            lastTelemetry: lastTelemetry
        )
    }
}

private func legacyStates() -> [String: LegacySourceSyncState] {
    let date = SourceSyncIndexFixtures.date
    func state(
        _ sourceID: String,
        _ index: [String: SourceSyncIndexedItem],
        configure: (inout LegacySourceSyncState) -> Void = { _ in }
    ) -> LegacySourceSyncState {
        var value = LegacySourceSyncState(
            schemaVersion: SourceSyncState.currentSchemaVersion, sourceID: sourceID,
            scopeFingerprint: "scope-\(sourceID)", identityScopeFingerprint: "identity-\(sourceID)",
            cursors: [:], index: index, pendingDirectories: [], scanEpoch: 7, requiresDeepScan: false,
            lastFullScanAt: date, lastSuccessfulSyncAt: date.addingTimeInterval(60), identityAliases: [:],
            rootIdentities: [], reconciliation: nil, missingStableKeys: [:], missingCatalogSongIDs: [:],
            deletionEvidenceRevision: nil, catalogSyncMarker: nil, lastTelemetry: nil
        )
        configure(&value)
        return value
    }
    let states = [
        state("smb-1", SourceSyncIndexFixtures.fileSystem()) {
            $0.cursors = ["/Music": "smb-snapshot-v2"]
            $0.pendingDirectories = ["/Music/未走完"]
            $0.rootIdentities = [SourceSyncRootIdentity(configuredPath: "/Music", currentPath: "/Music", stableKey: nil)]
        },
        state("navidrome-1", SourceSyncIndexFixtures.server(songs: 500)) {
            $0.missingCatalogSongIDs = [MusicIDs.song(9_999): 1]
            $0.deletionEvidenceRevision = "walk:r42:stage-1"
            $0.catalogSyncMarker = ServerCatalogSyncMarker(catalogRevision: "r42", modifiedSince: date, itemCount: 500)
            $0.reconciliation = SourceSyncReconciliation(
                kind: .serverCatalogMassDisappearance, unresolvedStableKeys: [MusicIDs.song(9_999)], detectedAt: date
            )
            $0.requiresDeepScan = true
        },
        state("cue-nas", SourceSyncIndexFixtures.cue()),
        state("books", SourceSyncIndexFixtures.spokenWord()) {
            $0.identityAliases = ["legacy-alias": "provider:prologue"]
        },
        state("gdrive-account", SourceSyncIndexFixtures.cloud()) {
            $0.cursors = ["0AKr8-root": "changes-token-123"]
            $0.rootIdentities = [SourceSyncRootIdentity(configuredPath: "0AKr8-root", currentPath: "0AKr8-root",
                                                        stableKey: "0AKr8-root")]
        },
        state("baidu", SourceSyncIndexFixtures.baidu()) {
            $0.cursors = [BaiduSnapshotIdentity.cursorKey: BaiduSnapshotIdentity.cursorVersion]
            $0.missingStableKeys = [BaiduSnapshotIdentity.stableKey(fsID: 77): 1]
            $0.reconciliation = SourceSyncReconciliation(
                kind: .baiduIdentityAndDeletionConfirmation,
                unresolvedStableKeys: [BaiduSnapshotIdentity.stableKey(fsID: 77)], detectedAt: date
            )
            $0.lastTelemetry = SourceSyncTelemetry(requestCount: 12, directoryCount: 3, elapsed: 1.5,
                                                   stopReason: .requests)
        },
        state("never-scanned", [:]) {
            $0.lastFullScanAt = nil
            $0.lastSuccessfulSyncAt = nil
            $0.identityScopeFingerprint = nil
        },
        state("源 \"引号\"/斜杠", SourceSyncIndexFixtures.cue()),
    ]
    return Dictionary(uniqueKeysWithValues: states.map { ($0.sourceID, $0) })
}

private func writeLegacy(_ states: [String: LegacySourceSyncState], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(states).write(to: url)
}

private func makeWorkspace() throws -> (root: URL, legacy: URL, directory: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("primuse-sync-directory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent("source-sync-states.json")
    return (root, legacy, SourceSyncStateDirectory.directory(forLegacySnapshot: legacy))
}

@Suite("Per-source sync state files and migration")
struct SourceSyncStateDirectoryTests {
    @Test("An old build's whole-file snapshot migrates to identical per-source state")
    func legacySnapshotMigratesExactly() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let legacy = legacyStates()
        try writeLegacy(legacy, to: workspace.legacy)
        // What the old build itself decoded at launch.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let oldBuildView = try decoder.decode(
            [String: LegacySourceSyncState].self, from: Data(contentsOf: workspace.legacy)
        )

        let result = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(result.problems.isEmpty)
        #expect(result.migratedSourceCount == legacy.count)
        #expect(result.legacySnapshotURL == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.legacy.path))
        #expect(Set(result.states.keys) == Set(legacy.keys))
        #expect(Set(result.records.keys) == Set(legacy.keys))
        for (sourceID, old) in oldBuildView {
            let migrated = try #require(result.states[sourceID])
            #expect(migrated == old.current, "\(sourceID)")
            #expect(migrated.index.dictionary == old.index, "\(sourceID)")
            #expect(migrated.missingCatalogSongIDs == old.missingCatalogSongIDs)
            #expect(migrated.catalogSyncMarker == old.catalogSyncMarker)
            #expect(migrated.reconciliation == old.reconciliation)
        }

        // A plain relaunch reads the same state back from the per-source files.
        let relaunch = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(relaunch.problems.isEmpty)
        #expect(relaunch.migratedSourceCount == nil)
        #expect(relaunch.states == result.states)
        #expect(relaunch.records == result.records)
        // The legacy name is gone, so an older build sees no state (one full scan) and no unreadable file.
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
        #expect(names == [SourceSyncStateDirectory.directoryName])
    }

    @Test("An interrupted migration is redone from the legacy file, which stays until verified")
    func interruptedMigrationIsRedone() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let legacy = legacyStates()
        try writeLegacy(legacy, to: workspace.legacy)
        // A crash after part of the staging directory was written, and one after the
        // old directory was moved aside but before the new one took its place.
        let staging = workspace.root.appendingPathComponent("source-sync-states.migrating")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("junk.state.json"))
        let replaced = workspace.root.appendingPathComponent("source-sync-states.replaced-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)

        let result = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(result.problems.isEmpty)
        #expect(result.states == legacy.mapValues(\.current))
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
        #expect(names == [SourceSyncStateDirectory.directoryName])
    }

    @Test("A legacy file written after migration (a downgrade) wins over the older per-source files")
    func legacyWrittenAfterDowngradeWins() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        var legacy = legacyStates()
        try writeLegacy(legacy, to: workspace.legacy)
        _ = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)

        // The older build scanned again and wrote its own snapshot, without one source.
        legacy["navidrome-1"]?.scanEpoch = 99
        legacy["navidrome-1"]?.index = SourceSyncIndexFixtures.server(songs: 20)
        legacy.removeValue(forKey: "cue-nas")
        try writeLegacy(legacy, to: workspace.legacy)

        let result = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(result.states == legacy.mapValues(\.current))
        #expect(result.states["cue-nas"] == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.legacy.path))
        let reread = SourceSyncStateDirectory.loadDirectory(workspace.directory)
        #expect(reread.states == legacy.mapValues(\.current))
    }

    @Test("A corrupt legacy file is moved aside and the per-source files still load")
    func corruptLegacyIsMovedAside() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let legacy = legacyStates()
        try writeLegacy(legacy, to: workspace.legacy)
        _ = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        try Data("{\"half\":".utf8).write(to: workspace.legacy)

        let result = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(result.states == legacy.mapValues(\.current))
        #expect(result.problems.count == 1)
        #expect(!FileManager.default.fileExists(atPath: workspace.legacy.path))
        #expect(FileManager.default.fileExists(atPath: workspace.legacy.path + ".corrupt"))
    }

    @Test("A damaged index keeps its source's other fields; a newer-format state file is skipped; files are kept")
    func damagedSourceIsSkippedAlone() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let legacy = legacyStates()
        try writeLegacy(legacy, to: workspace.legacy)
        let migrated = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)

        let damagedIndex = try #require(migrated.records["navidrome-1"]?.index?.file)
        let indexURL = workspace.directory.appendingPathComponent(damagedIndex)
        var bytes = try Data(contentsOf: indexURL)
        bytes[200] ^= 0xFF
        try bytes.write(to: indexURL)
        let newerStem = SourceSyncStateDirectory.fileStem(for: "books")
        let newerURL = workspace.directory.appendingPathComponent("\(newerStem).state.json")
        var envelope = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: newerURL)) as? [String: Any])
        envelope["format"] = SourceSyncStateDirectory.formatVersion + 1
        try JSONSerialization.data(withJSONObject: envelope).write(to: newerURL)

        let result = SourceSyncStateDirectory.loadDirectory(
            workspace.directory, now: Date().addingTimeInterval(3_600)
        )
        // 索引读不回来:其余字段(删歌证词、确认中的大批消失……)照旧,索引为空、记下基线丢了。
        var lostBaseline = try #require(legacy["navidrome-1"]?.current)
        lostBaseline.index = SourceSyncIndex()
        lostBaseline.indexBaselineLost = true
        #expect(result.states["navidrome-1"] == lostBaseline)
        // state.json 本身是更新的版本写的:整个源跳过。
        #expect(result.states["books"] == nil)
        #expect(result.problems.count == 2)
        var expected = legacy.mapValues(\.current)
        expected["navidrome-1"] = lostBaseline
        expected.removeValue(forKey: "books")
        #expect(result.states == expected)
        // Even past the orphan grace period, a skipped source's files are not cleaned up.
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        let booksIndex = try #require(migrated.records["books"]?.index?.file)
        #expect(FileManager.default.fileExists(atPath: workspace.directory.appendingPathComponent(booksIndex).path))
    }

    @Test("Orphaned index and temporary files are removed only after the grace period")
    func orphansAreRemovedAfterGrace() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try writeLegacy(legacyStates(), to: workspace.legacy)
        _ = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        let stem = SourceSyncStateDirectory.fileStem(for: "navidrome-1")
        let orphan = workspace.directory.appendingPathComponent("\(stem).\(UUID().uuidString).index")
        let temporary = workspace.directory.appendingPathComponent(".\(stem).state.json.tmp-\(UUID().uuidString)")
        try Data("x".utf8).write(to: orphan)
        try Data("x".utf8).write(to: temporary)

        _ = SourceSyncStateDirectory.loadDirectory(workspace.directory)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        let later = SourceSyncStateDirectory.loadDirectory(workspace.directory, now: Date().addingTimeInterval(3_600))
        #expect(later.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(later.states.count == legacyStates().count)
    }

    @Test("A crash between writing a new index and its state file keeps the previous state")
    func crashBeforeStateFileKeepsPreviousState() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let original = legacyStates()["navidrome-1"]!.current
        let record = try SourceSyncStateDirectory.writeSource(
            original, previous: nil, previousIndex: nil, in: workspace.directory
        )
        // The next commit's index reached the disk, then the process died before the
        // state file was replaced.
        var next = original
        next.index = SourceSyncIndex(SourceSyncIndexFixtures.server(songs: 3))
        let stem = SourceSyncStateDirectory.fileStem(for: original.sourceID)
        let stray = workspace.directory.appendingPathComponent("\(stem).\(UUID().uuidString).index")
        try next.index.binaryData().data.write(to: stray)

        let reloaded = SourceSyncStateDirectory.loadDirectory(workspace.directory)
        #expect(reloaded.states[original.sourceID] == original)
        #expect(reloaded.records[original.sourceID] == record)

        // The next successful commit of that source clears the stray file right away.
        let committed = try SourceSyncStateDirectory.writeSource(
            next, previous: record, previousIndex: original.index, in: workspace.directory
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path)
            .filter { $0.hasSuffix(".index") }
        let committedFile = try #require(committed.index?.file)
        #expect(files == [committedFile])
        #expect(SourceSyncStateDirectory.loadDirectory(workspace.directory).states[original.sourceID] == next)
    }

    @Test("Only metadata changes rewrite only the small file")
    func metadataOnlyChangeKeepsIndexFile() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let original = legacyStates()["smb-1"]!.current
        let first = try SourceSyncStateDirectory.writeSource(
            original, previous: nil, previousIndex: nil, in: workspace.directory
        )
        var rescoped = original
        rescoped.scopeFingerprint = "new-scope"
        rescoped.missingStableKeys = ["path:/music/x.flac": 1]
        let second = try SourceSyncStateDirectory.writeSource(
            rescoped, previous: first, previousIndex: original.index, in: workspace.directory
        )
        #expect(second.index == first.index)
        // An equal index rebuilt from scratch (a different storage) is reused too.
        var rebuilt = rescoped
        rebuilt.index = SourceSyncIndex(original.index.dictionary)
        let third = try SourceSyncStateDirectory.writeSource(
            rebuilt, previous: second, previousIndex: rescoped.index, in: workspace.directory
        )
        #expect(third.index == first.index)
        #expect(SourceSyncStateDirectory.loadDirectory(workspace.directory).states["smb-1"] == rescoped)
    }

    @Test("Removing a source deletes its files and nothing else")
    func removingASourceDeletesOnlyItsFiles() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let legacy = legacyStates()
        try writeLegacy(legacy, to: workspace.legacy)
        _ = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        try SourceSyncStateDirectory.removeSource("gdrive-account", in: workspace.directory)
        var expected = legacy.mapValues(\.current)
        expected.removeValue(forKey: "gdrive-account")
        #expect(SourceSyncStateDirectory.loadDirectory(workspace.directory).states == expected)
        let stem = SourceSyncStateDirectory.fileStem(for: "gdrive-account")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path)
            .filter { $0.hasPrefix(stem) }
        #expect(leftovers.isEmpty)
    }

    @Test("No legacy file and no directory is an empty, unpersisted start")
    func freshInstallStartsEmpty() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let result = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(result.states.isEmpty)
        #expect(result.records.isEmpty)
        #expect(result.legacySnapshotURL == nil)
        #expect(result.problems.isEmpty)
    }

    @Test("A migration that cannot write keeps the legacy file authoritative for this launch")
    func failedMigrationFallsBackToLegacyMode() throws {
        let workspace = try makeWorkspace()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.root.path)
            try? FileManager.default.removeItem(at: workspace.root)
        }
        let legacy = legacyStates()
        try writeLegacy(legacy, to: workspace.legacy)
        let before = try Data(contentsOf: workspace.legacy)
        // Nothing can be created next to the legacy file: no staging directory, no swap.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.root.path)

        let result = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(result.legacySnapshotURL == workspace.legacy)
        #expect(result.legacySnapshotIsPersisted)
        #expect(result.records.isEmpty)
        #expect(result.states == legacy.mapValues(\.current))
        #expect(result.problems.count == 1)
        #expect(try Data(contentsOf: workspace.legacy) == before)

        // Once writing works again the next launch migrates normally.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.root.path)
        let retried = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        #expect(retried.legacySnapshotURL == nil)
        #expect(retried.states == legacy.mapValues(\.current))
    }

    @Test("A failed source write keeps the sources already written and retries only the rest")
    func partialFlushFailureRetriesTheRest() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let legacy = legacyStates()
        let first = try #require(legacy["books"]?.current)
        let second = try #require(legacy["cue-nas"]?.current)
        let writer = FailingStemWriter(failingStem: SourceSyncStateDirectory.fileStem(for: second.sourceID))
        let store = SourceSyncStateFileStore(directory: workspace.directory, atomicWriter: writer.write)

        _ = try await store.upsert(first, expectedMutationEpoch: 0)
        await #expect(throws: (any Error).self) {
            try await store.upsert(second, expectedMutationEpoch: 0)
        }
        #expect(SourceSyncStateDirectory.loadDirectory(workspace.directory).states == ["books": first])
        let writesBeforeRetry = writer.writes(forStem: SourceSyncStateDirectory.fileStem(for: first.sourceID))

        #expect(try await store.upsert(second, expectedMutationEpoch: 0) != nil)
        #expect(SourceSyncStateDirectory.loadDirectory(workspace.directory).states
            == ["books": first, "cue-nas": second])
        // The retry wrote only the source that had failed.
        #expect(writer.writes(forStem: SourceSyncStateDirectory.fileStem(for: first.sourceID)) == writesBeforeRetry)
    }

    @Test("A store started from a migrated directory writes later commits per source")
    func storeContinuesFromMigratedDirectory() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try writeLegacy(legacyStates(), to: workspace.legacy)
        let loaded = SourceSyncStateDirectory.load(directory: workspace.directory, legacyURL: workspace.legacy)
        let store = SourceSyncStateFileStore(
            directory: workspace.directory, initialStates: loaded.states, persistedRecords: loaded.records
        )
        var books = try #require(loaded.states["books"])
        books.scanEpoch += 1
        books.index.removeValue(forKey: "legacy-alias")
        _ = try await store.upsert(books, expectedMutationEpoch: 0)
        // Unchanged sources are not rewritten: their index files keep their names.
        let after = SourceSyncStateDirectory.loadDirectory(workspace.directory)
        #expect(after.states["books"] == books)
        for (sourceID, record) in loaded.records where sourceID != "books" {
            #expect(after.records[sourceID] == record)
        }
        #expect(after.records["books"]?.index != loaded.records["books"]?.index)
    }
}

/// 写到指定源的文件时第一次失败,其余照常原子写入。
private final class FailingStemWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let failingStem: String
    private var failed = false
    private var counts: [String: Int] = [:]

    init(failingStem: String) {
        self.failingStem = failingStem
    }

    func writes(forStem stem: String) -> Int {
        lock.withLock { counts[stem, default: 0] }
    }

    func write(_ data: Data, _ url: URL) throws {
        let stem = String(url.lastPathComponent.prefix(32))
        let shouldFail = lock.withLock { () -> Bool in
            counts[stem, default: 0] += 1
            guard stem == failingStem, !failed else { return false }
            failed = true
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}
