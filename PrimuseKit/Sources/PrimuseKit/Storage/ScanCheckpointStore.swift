import Foundation

public enum ScanCheckpointPhase: String, Codable, Sendable {
    /// The scan intent is durable, but no protocol response has produced
    /// authoritative progress yet.
    case initial
    case scanning
}

public enum ScanCheckpointIntent: String, Codable, Sendable {
    case automatic
    case fullScan
    case quickOnly
}

/// Device-local, uncommitted scan progress. The file intentionally remains a
/// dictionary keyed by source ID so checkpoints written by earlier builds can
/// still be decoded.
public struct ScanCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var phase: ScanCheckpointPhase
    public var intent: ScanCheckpointIntent
    public var directories: [String]
    public var songs: [Song]
    public var totalCount: Int
    public var currentFile: String
    public var updatedAt: Date
    /// Account/provider/root scope that produced this progress. Older
    /// checkpoints decode as nil and are restarted before network I/O rather
    /// than being resumed against a possibly different cloud account.
    public var scopeFingerprint: String?
    /// Provider-resolved roots used by the in-progress queue. This can differ
    /// from `directories` when a stable Baidu root was renamed or moved.
    public var resolvedDirectories: [String]?
    /// Nil for checkpoints written by older builds; those safely restart from
    /// the selected roots.
    public var directoryState: SourceScanResumeState?
    /// Provider cursors captured before a deep scan remain uncommitted until
    /// both the resumed walk and the library snapshot succeed.
    public var baselineCursors: [String: String]?
    /// Uncommitted Baidu snapshot traversal. It is intentionally separate from
    /// `directoryState`: completing only part of a provider tree must never
    /// become authoritative for deletion, but the remaining queue can resume.
    public var baiduSnapshotState: BaiduSnapshotResumeState?
    public var baiduTelemetry: SourceSyncTelemetry?
    /// Uncommitted, authoritative-page progress for a Subsonic search3
    /// catalogue. `songs` contains only the staged candidate rows and is never
    /// published to MusicLibrary until this state reaches the terminal page.
    public var subsonicCatalogState: SubsonicCatalogResumeState?
    /// Automatic lifecycle resume failures use a durable backoff. Explicit
    /// user scans bypass this timestamp, while background transitions avoid
    /// retrying the same unavailable source in a tight loop.
    public var automaticResumeFailureCount: Int
    public var automaticResumeAfter: Date?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        phase: ScanCheckpointPhase,
        intent: ScanCheckpointIntent,
        directories: [String],
        songs: [Song],
        totalCount: Int,
        currentFile: String,
        updatedAt: Date,
        scopeFingerprint: String? = nil,
        resolvedDirectories: [String]? = nil,
        directoryState: SourceScanResumeState? = nil,
        baselineCursors: [String: String]? = nil,
        baiduSnapshotState: BaiduSnapshotResumeState? = nil,
        baiduTelemetry: SourceSyncTelemetry? = nil,
        subsonicCatalogState: SubsonicCatalogResumeState? = nil,
        automaticResumeFailureCount: Int = 0,
        automaticResumeAfter: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.intent = intent
        self.directories = directories
        self.songs = songs
        self.totalCount = totalCount
        self.currentFile = currentFile
        self.updatedAt = updatedAt
        self.scopeFingerprint = scopeFingerprint
        self.resolvedDirectories = resolvedDirectories
        self.directoryState = directoryState
        self.baselineCursors = baselineCursors
        self.baiduSnapshotState = baiduSnapshotState
        self.baiduTelemetry = baiduTelemetry
        self.subsonicCatalogState = subsonicCatalogState
        self.automaticResumeFailureCount = automaticResumeFailureCount
        self.automaticResumeAfter = automaticResumeAfter
    }

    public var isUsable: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !directories.isEmpty
            && totalCount >= 0
    }

    /// Only a pre-progress automatic/quick intent or an explicitly resumable
    /// snapshot may use stateful refresh. A full/deep scan must remain a full
    /// walk after a cold launch.
    public var permitsStatefulRefresh: Bool {
        (phase == .initial && intent != .fullScan)
            || (baiduSnapshotState != nil && intent != .fullScan)
    }

    public var isQuickOnly: Bool {
        phase == .initial && intent == .quickOnly
    }

    public func canAutomaticallyResume(at date: Date = Date()) -> Bool {
        automaticResumeAfter.map { $0 <= date } ?? true
    }

    public func recordingAutomaticResumeFailure(at date: Date = Date()) -> Self {
        var updated = self
        let failureCount = min(max(0, automaticResumeFailureCount) + 1, 8)
        let exponent = min(failureCount - 1, 6)
        let delay = min(6 * 60 * 60, 5 * 60 * (1 << exponent))
        updated.automaticResumeFailureCount = failureCount
        updated.automaticResumeAfter = date.addingTimeInterval(TimeInterval(delay))
        return updated
    }

    public func clearingAutomaticResumeFailure() -> Self {
        guard automaticResumeFailureCount != 0 || automaticResumeAfter != nil else {
            return self
        }
        var updated = self
        updated.automaticResumeFailureCount = 0
        updated.automaticResumeAfter = nil
        return updated
    }

    public func promotedToFullScan(at date: Date = Date()) -> Self {
        guard phase == .initial, intent != .fullScan else { return self }
        var promoted = self
        promoted.intent = .fullScan
        promoted.baiduSnapshotState = nil
        promoted.baiduTelemetry = nil
        promoted.subsonicCatalogState = nil
        promoted.updatedAt = date
        return promoted
    }

    /// A directory captured by an uncommitted provider snapshot can be moved
    /// before a cold resume. Restart the snapshot from its stable roots instead
    /// of retrying the stale path or promoting partial evidence to a deep scan.
    public func restartingSnapshotTraversal(
        telemetry: SourceSyncTelemetry,
        at date: Date = Date()
    ) -> Self {
        var restarted = self
        restarted.phase = .initial
        restarted.currentFile = ""
        restarted.resolvedDirectories = nil
        restarted.baiduSnapshotState = nil
        restarted.baiduTelemetry = telemetry
        restarted.updatedAt = date
        return restarted
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case phase
        case intent
        case directories
        case songs
        case totalCount
        case currentFile
        case updatedAt
        case scopeFingerprint
        case resolvedDirectories
        case directoryState
        case baselineCursors
        case baiduSnapshotState
        case baiduTelemetry
        case subsonicCatalogState
        case automaticResumeFailureCount
        case automaticResumeAfter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        // A legacy entry could only have been written after scanning had
        // produced progress, so never reinterpret it as a quick-sync intent.
        phase = try container.decodeIfPresent(ScanCheckpointPhase.self, forKey: .phase)
            ?? .scanning
        intent = try container.decodeIfPresent(ScanCheckpointIntent.self, forKey: .intent)
            ?? .fullScan
        directories = try container.decode([String].self, forKey: .directories)
        songs = try container.decode([Song].self, forKey: .songs)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
        currentFile = try container.decode(String.self, forKey: .currentFile)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        scopeFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .scopeFingerprint
        )
        resolvedDirectories = try container.decodeIfPresent(
            [String].self,
            forKey: .resolvedDirectories
        )
        directoryState = try container.decodeIfPresent(
            SourceScanResumeState.self,
            forKey: .directoryState
        )
        baselineCursors = try container.decodeIfPresent(
            [String: String].self,
            forKey: .baselineCursors
        )
        baiduSnapshotState = try container.decodeIfPresent(
            BaiduSnapshotResumeState.self,
            forKey: .baiduSnapshotState
        )
        baiduTelemetry = try container.decodeIfPresent(
            SourceSyncTelemetry.self,
            forKey: .baiduTelemetry
        )
        subsonicCatalogState = try container.decodeIfPresent(
            SubsonicCatalogResumeState.self,
            forKey: .subsonicCatalogState
        )
        automaticResumeFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .automaticResumeFailureCount
        ) ?? 0
        automaticResumeAfter = try container.decodeIfPresent(
            Date.self,
            forKey: .automaticResumeAfter
        )
    }
}

public enum ScanCheckpointPreparationPolicy {
    /// Preserves real progress for the same directory scope. Otherwise creates
    /// a restartable intent whose root queue is known before network I/O.
    public static func preparingCheckpoint(
        existing: ScanCheckpoint?,
        directories: [String],
        mode: SourceSyncMode,
        scopeFingerprint: String? = nil,
        now: Date = Date()
    ) -> ScanCheckpoint {
        if let existing,
           existing.isUsable,
           existing.directories == directories,
           scopeFingerprint == nil || existing.scopeFingerprint == scopeFingerprint {
            return existing
        }

        let intent: ScanCheckpointIntent
        switch mode {
        case .automatic:
            intent = .automatic
        case .quick:
            intent = .quickOnly
        case .deep:
            intent = .fullScan
        }
        return ScanCheckpoint(
            phase: .initial,
            intent: intent,
            directories: directories,
            songs: [],
            totalCount: 0,
            currentFile: "",
            updatedAt: now,
            scopeFingerprint: scopeFingerprint,
            directoryState: SourceScanResumeState(pendingDirectories: directories)
        )
    }
}

public enum ScanCheckpointSourceDisposition: Equatable, Sendable {
    case resume
    case retain
    case discard
}

public enum ScanCheckpointSourcePolicy {
    /// Missing and deleted sources cannot become live again from device-local
    /// progress. Disabled sources retain an explicit user-resumable checkpoint
    /// but are never launched automatically.
    public static func disposition(
        sourceExists: Bool,
        isEnabled: Bool,
        isDeleted: Bool
    ) -> ScanCheckpointSourceDisposition {
        guard sourceExists, !isDeleted else { return .discard }
        return isEnabled ? .resume : .retain
    }
}

public enum ScanCheckpointStoreError: Error, Equatable {
    case invalidCheckpoint(String)
}

/// Serial checkpoint mutations plus a recoverable atomic JSON snapshot. The
/// previous readable destination is retained as a backup until the next valid
/// replacement succeeds.
public actor ScanCheckpointFileStore {
    public typealias AtomicWriter = @Sendable (
        _ data: Data,
        _ destinationURL: URL,
        _ backupURL: URL,
        _ preserveExistingAsBackup: Bool
    ) throws -> Void

    public static let defaultAtomicWriter: AtomicWriter = {
        data, destinationURL, backupURL, preserveExistingAsBackup in
        try AtomicBackupFileWriter.write(
            data,
            to: destinationURL,
            backupURL: backupURL,
            preserveExistingAsBackup: preserveExistingAsBackup
        )
    }

    private let checkpointURL: URL
    private let backupURL: URL
    private let atomicWriter: AtomicWriter
    private var checkpoints: [String: ScanCheckpoint]

    public init(
        checkpointURL: URL,
        backupURL: URL? = nil,
        initialCheckpoints: [String: ScanCheckpoint]? = nil,
        atomicWriter: @escaping AtomicWriter = ScanCheckpointFileStore.defaultAtomicWriter
    ) {
        let resolvedBackupURL = backupURL ?? Self.defaultBackupURL(for: checkpointURL)
        self.checkpointURL = checkpointURL
        self.backupURL = resolvedBackupURL
        self.atomicWriter = atomicWriter
        self.checkpoints = initialCheckpoints ?? Self.load(
            from: checkpointURL,
            backupURL: resolvedBackupURL
        )
    }

    public func snapshot() -> [String: ScanCheckpoint] {
        checkpoints
    }

    public func replace(with snapshot: [String: ScanCheckpoint]) throws {
        try Self.writeSnapshot(
            snapshot,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter
        )
        checkpoints = snapshot
    }

    public func upsert(_ checkpoint: ScanCheckpoint, for sourceID: String) throws {
        guard checkpoint.isUsable else {
            throw ScanCheckpointStoreError.invalidCheckpoint(sourceID)
        }
        var candidate = checkpoints
        candidate[sourceID] = checkpoint
        try Self.writeSnapshot(
            candidate,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter
        )
        checkpoints = candidate
    }

    public func remove(sourceID: String) throws {
        var candidate = checkpoints
        candidate[sourceID] = nil
        try Self.writeSnapshot(
            candidate,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter
        )
        checkpoints = candidate
    }

    public nonisolated static func defaultBackupURL(for checkpointURL: URL) -> URL {
        checkpointURL.deletingPathExtension().appendingPathExtension("backup.json")
    }

    public nonisolated static func load(
        from checkpointURL: URL,
        backupURL: URL? = nil
    ) -> [String: ScanCheckpoint] {
        let resolvedBackupURL = backupURL ?? defaultBackupURL(for: checkpointURL)
        for candidateURL in [checkpointURL, resolvedBackupURL] {
            guard let data = try? Data(contentsOf: candidateURL),
                  let decoded = decodeRecoveringValidEntries(from: data) else {
                continue
            }
            return decoded
        }
        return [:]
    }

    public nonisolated static func writeSnapshot(
        _ checkpoints: [String: ScanCheckpoint],
        to checkpointURL: URL,
        backupURL: URL? = nil,
        atomicWriter: AtomicWriter = ScanCheckpointFileStore.defaultAtomicWriter
    ) throws {
        if let invalid = checkpoints.first(where: { !$0.value.isUsable }) {
            throw ScanCheckpointStoreError.invalidCheckpoint(invalid.key)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoints)
        let resolvedBackupURL = backupURL ?? defaultBackupURL(for: checkpointURL)
        let preserveExistingAsBackup: Bool
        if let currentData = try? Data(contentsOf: checkpointURL) {
            preserveExistingAsBackup = isTrustedSnapshotData(currentData)
        } else {
            preserveExistingAsBackup = false
        }
        try atomicWriter(
            data,
            checkpointURL,
            resolvedBackupURL,
            preserveExistingAsBackup
        )
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private nonisolated static func isTrustedSnapshotData(_ data: Data) -> Bool {
        guard let decoded = try? decoder().decode([String: ScanCheckpoint].self, from: data) else {
            return false
        }
        return decoded.values.allSatisfy(\.isUsable)
    }

    private nonisolated static func decodeRecoveringValidEntries(
        from data: Data
    ) -> [String: ScanCheckpoint]? {
        if let decoded = try? decoder().decode([String: ScanCheckpoint].self, from: data) {
            return decoded.filter { $0.value.isUsable }
        }

        // A single malformed source entry must not erase unrelated sources.
        // If the root JSON object itself is truncated, loading falls through
        // to the previous atomic backup instead.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rawEntries = object as? [String: Any] else {
            return nil
        }
        var recovered: [String: ScanCheckpoint] = [:]
        for (sourceID, rawEntry) in rawEntries {
            guard JSONSerialization.isValidJSONObject([sourceID: rawEntry]),
                  let entryData = try? JSONSerialization.data(
                    withJSONObject: [sourceID: rawEntry]
                  ),
                  let entry = try? decoder().decode(
                    [String: ScanCheckpoint].self,
                    from: entryData
                  )[sourceID],
                  entry.isUsable else {
                continue
            }
            recovered[sourceID] = entry
        }
        return recovered
    }
}

public struct SourceSyncStateWriteReceipt: Sendable, Equatable {
    public let sourceID: String
    public let mutationEpoch: UInt64
    public let sourceRevision: UInt64

    public init(sourceID: String, mutationEpoch: UInt64, sourceRevision: UInt64) {
        self.sourceID = sourceID
        self.mutationEpoch = mutationEpoch
        self.sourceRevision = sourceRevision
    }
}

/// Serializes per-source cursor/index mutations into one atomic snapshot.
/// Each caller contributes only its source row, so concurrent scan completions
/// cannot replace another source's freshly committed state with an older map.
public actor SourceSyncStateFileStore {
    public typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    private let url: URL
    private let atomicWriter: AtomicWriter
    private var states: [String: SourceSyncState]
    private var mutationEpochs: [String: UInt64] = [:]
    private var sourceRevisions: [String: UInt64] = [:]

    public init(
        url: URL,
        initialStates: [String: SourceSyncState] = [:],
        atomicWriter: @escaping AtomicWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.url = url
        self.states = initialStates
        self.atomicWriter = atomicWriter
    }

    /// An epoch is advanced synchronously by the source-change observer. A
    /// later-arriving write from the previous credential/configuration scope
    /// is rejected even if its network task suspended before cancellation.
    public func upsert(
        _ state: SourceSyncState,
        expectedMutationEpoch: UInt64
    ) throws -> SourceSyncStateWriteReceipt? {
        let sourceID = state.sourceID
        let currentEpoch = mutationEpochs[sourceID, default: 0]
        guard expectedMutationEpoch >= currentEpoch else { return nil }

        var candidate = states
        if expectedMutationEpoch > currentEpoch {
            candidate[sourceID] = nil
        }
        candidate[sourceID] = state
        let revision = sourceRevisions[sourceID, default: 0] &+ 1
        try write(candidate)
        states = candidate
        mutationEpochs[sourceID] = expectedMutationEpoch
        sourceRevisions[sourceID] = revision
        return SourceSyncStateWriteReceipt(
            sourceID: sourceID,
            mutationEpoch: expectedMutationEpoch,
            sourceRevision: revision
        )
    }

    /// Removes stale cursor/topology state for a persisted source edit. If a
    /// new-scope write reaches the actor first, the equal delayed invalidation
    /// is a no-op and cannot erase that newer state.
    public func invalidate(
        sourceID: String,
        mutationEpoch: UInt64
    ) throws -> SourceSyncStateWriteReceipt? {
        try advanceMutationEpoch(
            sourceID: sourceID,
            mutationEpoch: mutationEpoch,
            discardingState: true
        )
    }

    /// A cancelled scan advances the write fence without discarding the last
    /// committed cursor. This prevents its suspended write from arriving after
    /// a replacement generation while retaining safe resume state.
    public func advanceMutationEpoch(
        sourceID: String,
        mutationEpoch: UInt64,
        discardingState: Bool = false
    ) throws -> SourceSyncStateWriteReceipt? {
        let currentEpoch = mutationEpochs[sourceID, default: 0]
        guard mutationEpoch > currentEpoch else { return nil }

        var candidate = states
        if discardingState {
            candidate[sourceID] = nil
        }
        let revision = sourceRevisions[sourceID, default: 0] &+ 1
        if discardingState {
            try write(candidate)
        }
        states = candidate
        mutationEpochs[sourceID] = mutationEpoch
        sourceRevisions[sourceID] = revision
        return SourceSyncStateWriteReceipt(
            sourceID: sourceID,
            mutationEpoch: mutationEpoch,
            sourceRevision: revision
        )
    }

    public func snapshot() -> [String: SourceSyncState] {
        states
    }

    private func write(_ states: [String: SourceSyncState]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try atomicWriter(try encoder.encode(states), url)
    }
}
